# Stercorarius Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Status:** executed on 2026-11-04. Where the code differs from the snippets below, the repository is authoritative: lint-driven tweaks, plus two user requests added during implementation, a random start point for each beetle (`PassPlanner.plan(progress:)`) and the Beetle Size menu (`BeetleSize.swift`).

**Goal:** A macOS menu-bar app that shows one animated dung beetle per Claude Code or Codex session while that session is working.

**Architecture:** A 1 s poll reads Claude Code's own session registry (`~/.claude/sessions/*.json`) and the Codex state directory (`~/.stercorarius/codex/*.json`, written by the app binary's `codex-hook` subcommand that Codex hooks call). One transparent, click-through overlay window per display hosts a `CALayer` per working session; Core Animation plays the walk cycle and moves the layer across the display.

**Tech Stack:** Swift 6 (strict concurrency), AppKit, QuartzCore, ImageIO, libproc, Swift Testing, SwiftPM; bash + `/usr/bin/jq` for the hook installer; make.

**Spec:** `docs/superpowers/specs/2026-11-04-stercorarius-design.md`

## Global Constraints

- macOS 15+, Swift tools 6.0, no third-party dependencies.
- Bundle ID `com.jamg.Stercorarius`; app name and executable `Stercorarius`; accessory app (`LSUIElement`).
- Claude working = registry record `status == "busy"` and live PID; `waiting` and `idle` are not working. Never write to `~/.claude`; read only `*.json` there.
- Codex hooks: `UserPromptSubmit` → `<app>/Contents/MacOS/Stercorarius codex-hook busy`; `Stop`, `Interrupt`, `SessionEnd` → `… codex-hook idle`. State file `~/.stercorarius/codex/<session_id>.json` = `{"pid": N, "status": "busy"}`.
- `codex-hook` prints nothing to stdout and always exits 0.
- Liveness: `proc_pidpath` succeeds and the lowercased path contains `claude` / `codex`.
- Sprite display size = frame px ÷ `meta.pixelRatio` (221 pt); speed 100 pt/s; fade-out 0.3 s; overlay level `.screenSaver`; collection behavior `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`; heights inside `visibleFrame`.
- Installer only touches `.hooks.<Event>` arrays, appends at the end, is idempotent (byte-identical second run), backs up before changing, validates with jq before replacing.
- Zero warnings: build with `-Xswiftc -warnings-as-errors`; `swiftlint --strict`; `swift format lint --strict`; `shellcheck`; `shfmt -d -i 2`.
- Never use `rm -rf`; use `trash` for removals outside temp dirs.
- Lines ≤ 100 characters.

---

### Task 1: Package scaffold, sprite pack, session records, process lookups

**Files:**
- Create: `Package.swift`, `.swiftlint.yml`, `.swift-format`
- Create: `Sources/Stercorarius/main.swift` (empty entry point for now)
- Create: `Sources/Stercorarius/Agent.swift`, `Sources/Stercorarius/Processes.swift`
- Create: `Sources/Stercorarius/Resources/Sprites/*` (unzipped sprite pack, unchanged)
- Test: `Tests/StercorariusTests/TestSupport.swift`, `Tests/StercorariusTests/AgentTests.swift`, `Tests/StercorariusTests/ProcessesTests.swift`

**Interfaces:**
- Produces:
  - `enum Agent: String, CaseIterable, Sendable { case claude, codex }` with `displayName: String`, `spriteName: String`, `func sessionDirectory(home: URL) -> URL`
  - `struct Session: Hashable, Sendable { let agent: Agent; let id: String }`
  - `struct SessionRecord: Codable, Equatable, Sendable { let pid: Int32; let status: String; static let busyStatus = "busy"; var isBusy: Bool }`
  - `enum Processes { static func executablePath(of: Int32) -> String?; static func parent(of: Int32) -> Int32?; static func isAlive(_: Int32, agent: Agent) -> Bool; static func ancestor(of: Int32, executablePrefix: String, maxDepth: Int = 8) -> Int32? }`
  - Test helpers `makeTemporaryDirectory() throws -> URL`, `writeFile(_ text: String, named: String, in: URL) throws`

- [ ] **Step 1: Create the package manifest, lint configs and empty entry point**

`Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Stercorarius",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Stercorarius",
            resources: [.copy("Resources/Sprites")]
        ),
        .testTarget(
            name: "StercorariusTests",
            dependencies: ["Stercorarius"]
        ),
    ]
)
```

`.swiftlint.yml`:

```yaml
included:
  - Package.swift
  - Sources
  - Tests
disabled_rules:
  - trailing_comma # swift-format adds trailing commas to multi-line collections
line_length:
  warning: 100
identifier_name:
  excluded:
    - x
    - y
    - w
    - h
    - id
```

`.swift-format`:

```json
{
  "version": 1,
  "lineLength": 100,
  "indentation": { "spaces": 4 },
  "respectsExistingLineBreaks": true
}
```

`Sources/Stercorarius/main.swift`:

```swift
// Entry point. Task 3 adds the `codex-hook` subcommand, Task 6 the app.
```

- [ ] **Step 2: Unpack the sprite pack unchanged**

```bash
mkdir -p Sources/Stercorarius/Resources/Sprites
unzip -j -o ~/Downloads/beetle-agents-realistic-retina.zip -d Sources/Stercorarius/Resources/Sprites
ls Sources/Stercorarius/Resources/Sprites
```

Expected: `README.md chatgpt-codex.json chatgpt-codex.png claude-code.json claude-code.png generation-prompts.json preview.html sprite-pack.json`.

- [ ] **Step 3: Write the failing tests**

`Tests/StercorariusTests/TestSupport.swift`:

```swift
import Foundation

/// A new empty directory under the temporary directory; the caller removes it.
func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "stercorarius-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes `text` as UTF-8 to the file `name` inside `directory`.
func writeFile(_ text: String, named name: String, in directory: URL) throws {
    try Data(text.utf8).write(to: directory.appending(path: name))
}
```

`Tests/StercorariusTests/AgentTests.swift`:

```swift
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
```

`Tests/StercorariusTests/ProcessesTests.swift`:

```swift
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
```

The temp directory may itself contain `claude` (agents run under `/private/tmp/claude-501/…`), so the negative liveness check uses `.codex` with a non-codex name.

- [ ] **Step 4: Run tests to verify they fail**

Run: `swift test 2>&1 | tail -20`
Expected: compile errors `cannot find 'SessionRecord' in scope`, `cannot find 'Processes' in scope`.

- [ ] **Step 5: Implement `Agent.swift`**

```swift
import Foundation

/// A coding agent whose working sessions get a beetle.
enum Agent: String, CaseIterable, Sendable {
    case claude
    case codex

    /// Name shown in the menu-bar status line.
    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    /// Base name of this agent's files in `Resources/Sprites`.
    var spriteName: String {
        switch self {
        case .claude: "claude-code"
        case .codex: "chatgpt-codex"
        }
    }

    /// Directory of this agent's session records: Claude Code's own registry, or the directory
    /// that `Stercorarius codex-hook` maintains for Codex.
    func sessionDirectory(home: URL) -> URL {
        switch self {
        case .claude: home.appending(path: ".claude/sessions", directoryHint: .isDirectory)
        case .codex: home.appending(path: ".stercorarius/codex", directoryHint: .isDirectory)
        }
    }
}

/// One session of one agent, identified by its record's file name.
struct Session: Hashable, Sendable {
    let agent: Agent
    let id: String
}

/// The part of a session record that Stercorarius reads. Claude Code's registry files carry more
/// fields, which are ignored; the Codex records written by `codex-hook` carry exactly these.
struct SessionRecord: Codable, Equatable, Sendable {
    let pid: Int32
    let status: String

    static let busyStatus = "busy"

    var isBusy: Bool { status == Self.busyStatus }
}
```

- [ ] **Step 6: Implement `Processes.swift`**

```swift
import Darwin

/// Process-table lookups backed by libproc.
enum Processes {
    /// Absolute path of the executable running as `pid`, or nil if there is no such process.
    static func executablePath(of pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) is not importable into Swift.
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer[..<Int(length)], as: UTF8.self)
    }

    /// Parent of `pid`, or nil if there is no such process.
    static func parent(of pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(bitPattern: info.pbi_ppid)
    }

    /// True when `pid` exists and its executable path mentions the agent (`…/claude`,
    /// `…/claude.exe`, `…/claude/versions/2.1.0`, `…/codex`). The name check rejects PIDs that an
    /// unrelated program reused after the agent died.
    static func isAlive(_ pid: Int32, agent: Agent) -> Bool {
        guard pid > 0, let path = executablePath(of: pid) else { return false }
        return path.lowercased().contains(agent.rawValue)
    }

    /// Nearest strict ancestor of `pid` whose executable file name starts with `prefix`,
    /// looking at most `maxDepth` levels up.
    static func ancestor(of pid: Int32, executablePrefix prefix: String, maxDepth: Int = 8)
        -> Int32?
    {
        var candidate = parent(of: pid)
        for _ in 0..<maxDepth {
            guard let current = candidate, current > 1 else { return nil }
            if let name = executablePath(of: current)?.split(separator: "/").last,
                name.lowercased().hasPrefix(prefix)
            {
                return current
            }
            candidate = parent(of: current)
        }
        return nil
    }
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `swift test -Xswiftc -warnings-as-errors 2>&1 | tail -20`
Expected: all `AgentTests` and `ProcessesTests` pass, no warnings.

- [ ] **Step 8: Lint**

Run: `swiftlint lint --strict --quiet && swift format lint --strict --recursive Package.swift Sources Tests`
Expected: no output. If `swift format` reports formatting, run `swift format --in-place --recursive Package.swift Sources Tests` and re-check.

- [ ] **Step 9: Commit**

```bash
git add Package.swift .swiftlint.yml .swift-format Sources Tests
git commit -m "Add package scaffold, sprite pack, session records and process lookups"
```

---

### Task 2: Session scanner

**Files:**
- Create: `Sources/Stercorarius/SessionScanner.swift`
- Test: `Tests/StercorariusTests/SessionScannerTests.swift`

**Interfaces:**
- Consumes: `Agent`, `Session`, `SessionRecord`, `Processes.isAlive(_:agent:)`, test helpers.
- Produces: `struct SessionScanner { let directories: [Agent: URL]; var isAlive: (Int32, Agent) -> Bool = Processes.isAlive; func busySessions() -> Set<Session>; static func records(in: URL) -> [String: SessionRecord] }`

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SessionScannerTests 2>&1 | tail -5`
Expected: compile error `cannot find 'SessionScanner' in scope`.

- [ ] **Step 3: Implement `SessionScanner.swift`**

```swift
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
            do {
                let data = try Data(contentsOf: file)
                records[file.deletingPathExtension().lastPathComponent] =
                    try JSONDecoder().decode(SessionRecord.self, from: data)
            } catch {
                logger.debug(
                    "Skipping \(file.path, privacy: .public): \(error.localizedDescription)")
            }
        }
        return records
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test -Xswiftc -warnings-as-errors --filter SessionScannerTests 2>&1 | tail -5`
Expected: 4 tests pass.

- [ ] **Step 5: Lint and commit**

```bash
swiftlint lint --strict --quiet && swift format lint --strict --recursive Sources Tests
git add Sources/Stercorarius/SessionScanner.swift Tests/StercorariusTests/SessionScannerTests.swift
git commit -m "Add session scanner for agent session records"
```

---

### Task 3: `codex-hook` subcommand

**Files:**
- Create: `Sources/Stercorarius/CodexHook.swift`
- Modify: `Sources/Stercorarius/main.swift` (whole file below)
- Test: `Tests/StercorariusTests/CodexHookTests.swift`

**Interfaces:**
- Consumes: `Agent.sessionDirectory(home:)`, `SessionRecord`, `SessionScanner.records(in:)`, `Processes.ancestor(of:executablePrefix:)`, `Processes.isAlive(_:agent:)`.
- Produces: `struct CodexHook { enum Action: String { case busy, idle }; let stateDirectory: URL; let codexHome: URL; var findAgentPID: () -> Int32?; var isAlive: (Int32) -> Bool; static func execute(arguments: [String]) -> Int32; func run(_ action: Action, input: Data); static func isValidSessionID(_: String) -> Bool }`

- [ ] **Step 1: Write the failing tests**

```swift
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

    private func payload(session: String = "01a1-thread", cwd: String = "/work", agent: String? = nil)
        throws -> Data
    {
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CodexHookTests 2>&1 | tail -5`
Expected: compile error `cannot find 'CodexHook' in scope`.

- [ ] **Step 3: Implement `CodexHook.swift`**

```swift
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

    /// The hook input fields Stercorarius uses.
    struct Payload: Decodable {
        let sessionId: String
        let cwd: String?
        let agentId: String?

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case cwd
            case agentId = "agent_id"
        }
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
            payload = try JSONDecoder().decode(Payload.self, from: input)
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
        (1...128).contains(id.count)
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
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
```

`Sources/Stercorarius/main.swift`:

```swift
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "codex-hook" {
    exit(CodexHook.execute(arguments: Array(arguments.dropFirst())))
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test -Xswiftc -warnings-as-errors --filter CodexHookTests 2>&1 | tail -5`
Expected: all CodexHookTests pass (parameterized test counts 6 cases).

- [ ] **Step 5: Smoke-test the real binary**

```bash
swift build
STATE_HOME=$(mktemp -d)
echo '{"session_id":"smoke-1","cwd":"/tmp"}' | HOME=$STATE_HOME .build/debug/Stercorarius codex-hook busy; echo "exit=$?"
ls "$STATE_HOME/.stercorarius/codex" 2>&1
```

Expected: `exit=0`, stderr `stercorarius codex-hook: no codex process among the hook's ancestors` (the shell is not codex), and no state directory. This proves the "no ancestor → write nothing, exit 0" path end to end.

- [ ] **Step 6: Lint and commit**

```bash
swiftlint lint --strict --quiet && swift format lint --strict --recursive Sources Tests
git add Sources/Stercorarius/CodexHook.swift Sources/Stercorarius/main.swift Tests/StercorariusTests/CodexHookTests.swift
git commit -m "Add codex-hook subcommand recording working Codex sessions"
```

---

### Task 4: Sprite sheet loader

**Files:**
- Create: `Sources/Stercorarius/SpriteSheet.swift`
- Test: `Tests/StercorariusTests/SpriteSheetTests.swift`

**Interfaces:**
- Consumes: `Agent.spriteName`, bundled `Resources/Sprites`.
- Produces: `struct SpriteSheet { struct Frame { let image: CGImage; let duration: TimeInterval }; enum LoadError: Error, CustomStringConvertible; let frames: [Frame]; let size: CGSize; var cycleDuration: TimeInterval; var keyTimes: [NSNumber]; static func bundled(for: Agent) throws -> SpriteSheet; static func load(name: String, in: URL) throws -> SpriteSheet }`

- [ ] **Step 1: Write the failing tests**

```swift
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Stercorarius

@Suite final class SpriteSheetTests {
    private let directory: URL

    init() throws { directory = try makeTemporaryDirectory() }

    deinit { try? FileManager.default.removeItem(at: directory) }

    @Test func bundledSpritesHaveEightFramesAt221Points() throws {
        for agent in Agent.allCases {
            let sheet = try SpriteSheet.bundled(for: agent)
            #expect(sheet.frames.count == 8)
            #expect(sheet.size == CGSize(width: 221, height: 221))
            #expect(abs(sheet.cycleDuration - 0.8) < 1e-9)
            #expect(sheet.frames.allSatisfy { $0.image.width == 442 && $0.image.height == 442 })
        }
    }

    @Test func cutsFramesInAnimationOrderAndBakesRenderOffsets() throws {
        try writeTwoFrameSheet()

        let sheet = try SpriteSheet.load(name: "beetle", in: directory)

        #expect(sheet.size == CGSize(width: 1.5, height: 2))
        #expect(sheet.frames.map(\.duration) == [0.25, 0.1])
        // Frame "b" plays first; its single pixel moved right 1 and down 2.
        let shifted = try alphaRows(of: try #require(sheet.frames.first).image)
        #expect(shifted == [[0, 0, 0], [0, 0, 0], [0, 255, 0], [0, 0, 0]])
        let block = try alphaRows(of: try #require(sheet.frames.last).image)
        #expect(block == Array(repeating: [255, 255, 255], count: 4))
    }

    @Test func keyTimesStartAtZeroAndCloseAtOne() throws {
        try writeTwoFrameSheet()

        let times = try SpriteSheet.load(name: "beetle", in: directory).keyTimes.map(\.doubleValue)

        #expect(times.count == 3)
        #expect(times.first == 0)
        #expect(abs((times.dropFirst().first ?? 0) - 0.25 / 0.35) < 1e-9)
        #expect(times.last == 1)
    }

    @Test func unknownFrameNameFails() throws {
        try writeAtlas(width: 1, height: 1, opaque: [(0, 0)])
        try writeMetadata(
            #"{"frames": {}, "animations": {"move_right": {"frames": ["ghost"]}},"#
                + #" "meta": {"pixelRatio": 2}}"#)
        #expect(throws: SpriteSheet.LoadError.self) {
            try SpriteSheet.load(name: "beetle", in: self.directory)
        }
    }

    @Test func emptyAnimationFails() throws {
        try writeAtlas(width: 1, height: 1, opaque: [])
        try writeMetadata(#"{"frames": {}, "animations": {}, "meta": {"pixelRatio": 2}}"#)
        #expect(throws: SpriteSheet.LoadError.self) {
            try SpriteSheet.load(name: "beetle", in: self.directory)
        }
    }

    @Test func missingAtlasFails() throws {
        try writeMetadata(#"{"frames": {}, "animations": {}, "meta": {"pixelRatio": 2}}"#)
        #expect(throws: SpriteSheet.LoadError.self) {
            try SpriteSheet.load(name: "beetle", in: self.directory)
        }
    }

    /// A 7×4 atlas: frame "a" is an opaque 3×4 block at x 0...2; frame "b" at x 4...6 has one
    /// opaque pixel in its top-left corner and `renderOffsetPx` (1, 2). Plays "b", then "a".
    private func writeTwoFrameSheet() throws {
        let block = (0..<3).flatMap { x in (0..<4).map { y in (x, y) } }
        try writeAtlas(width: 7, height: 4, opaque: block + [(4, 0)])
        try writeMetadata(
            """
            {
              "frames": {
                "a": {"frame": {"x": 0, "y": 0, "w": 3, "h": 4}, "durationMs": 100,
                      "renderOffsetPx": {"x": 0, "y": 0}},
                "b": {"frame": {"x": 4, "y": 0, "w": 3, "h": 4}, "durationMs": 250,
                      "renderOffsetPx": {"x": 1, "y": 2}}
              },
              "animations": {"move_right": {"frames": ["b", "a"]}},
              "meta": {"pixelRatio": 2}
            }
            """)
    }

    private func writeMetadata(_ json: String) throws {
        try writeFile(json, named: "beetle.json", in: directory)
    }

    /// Writes `beetle.png`: transparent except opaque white `pixels` (x, y from the top left).
    private func writeAtlas(width: Int, height: Int, opaque pixels: [(Int, Int)]) throws {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for (x, y) in pixels {
            let start = (y * width + x) * 4
            rgba.replaceSubrange(start..<start + 4, with: [255, 255, 255, 255])
        }
        let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
        let image = try #require(
            CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent))
        let url = directory.appending(path: "beetle.png")
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// Alpha of every pixel of `image`, rows from the top.
    private func alphaRows(of image: CGImage) throws -> [[UInt8]] {
        let width = image.width
        let height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        try rgba.withUnsafeMutableBytes { buffer in
            let context = try #require(
                CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (0..<height).map { row in
            (0..<width).map { column in rgba[(row * width + column) * 4 + 3] }
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SpriteSheetTests 2>&1 | tail -5`
Expected: compile error `cannot find 'SpriteSheet' in scope`.

- [ ] **Step 3: Implement `SpriteSheet.swift`**

```swift
import CoreGraphics
import Foundation
import ImageIO

/// An agent's walk cycle, cut from a TexturePacker-style atlas: `<name>.png` plus `<name>.json`
/// (format described in `Resources/Sprites/README.md`).
struct SpriteSheet {
    struct Frame {
        let image: CGImage
        let duration: TimeInterval
    }

    enum LoadError: Error, CustomStringConvertible {
        case unreadableAtlas(URL)
        case emptyAnimation(String)
        case missingFrame(String)
        case invalidFrame(String)

        var description: String {
            switch self {
            case .unreadableAtlas(let url): "cannot read sprite atlas \(url.path)"
            case .emptyAnimation(let name): "\(name).json has no move_right frames"
            case .missingFrame(let frame): "move_right refers to unknown frame \(frame)"
            case .invalidFrame(let frame): "frame \(frame) has an invalid size or duration"
            }
        }
    }

    let frames: [Frame]
    /// Display size in points: frame pixels ÷ the atlas pixel ratio.
    let size: CGSize

    /// Length of one walk cycle.
    var cycleDuration: TimeInterval { frames.reduce(0) { $0 + $1.duration } }

    /// Key times for a discrete keyframe animation over `frames`: each frame's start normalized
    /// to 0...1, plus a closing 1 (discrete mode takes one more key time than values).
    var keyTimes: [NSNumber] {
        let total = cycleDuration
        var elapsed: TimeInterval = 0
        var times: [NSNumber] = []
        for frame in frames {
            times.append(NSNumber(value: elapsed / total))
            elapsed += frame.duration
        }
        times.append(1)
        return times
    }
}

extension SpriteSheet {
    /// The sprite bundled for `agent`.
    static func bundled(for agent: Agent) throws -> SpriteSheet {
        guard let directory = Bundle.module.url(forResource: "Sprites", withExtension: nil) else {
            throw LoadError.unreadableAtlas(Bundle.module.bundleURL.appending(path: "Sprites"))
        }
        return try load(name: agent.spriteName, in: directory)
    }

    /// Loads `<name>.json` and `<name>.png` from `directory` and cuts the `move_right` frames.
    static func load(name: String, in directory: URL) throws -> SpriteSheet {
        let metadataURL = directory.appending(path: "\(name).json")
        let metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: metadataURL))
        let atlasURL = directory.appending(path: "\(name).png")
        guard let source = CGImageSourceCreateWithURL(atlasURL as CFURL, nil),
            let atlas = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw LoadError.unreadableAtlas(atlasURL) }

        var frames: [Frame] = []
        var pixelSize: CGSize?
        for frameName in metadata.animations["move_right"]?.frames ?? [] {
            guard let info = metadata.frames[frameName] else {
                throw LoadError.missingFrame(frameName)
            }
            let size = CGSize(width: info.frame.w, height: info.frame.h)
            guard info.durationMs > 0, pixelSize == nil || pixelSize == size else {
                throw LoadError.invalidFrame(frameName)
            }
            pixelSize = size
            let image = try render(info, from: atlas, frameName: frameName)
            frames.append(Frame(image: image, duration: info.durationMs / 1000))
        }
        let ratio = metadata.meta.pixelRatio
        guard let pixelSize, ratio > 0 else { throw LoadError.emptyAnimation(name) }
        return SpriteSheet(
            frames: frames,
            size: CGSize(width: pixelSize.width / ratio, height: pixelSize.height / ratio))
    }

    /// Cuts one frame out of the atlas into a transparent frame-sized image, shifted by
    /// `renderOffsetPx` (top-left origin: positive y moves the art down).
    private static func render(
        _ info: Metadata.FrameInfo, from atlas: CGImage, frameName: String
    ) throws -> CGImage {
        let rect = info.frame
        guard rect.w > 0, rect.h > 0,
            let piece = atlas.cropping(
                to: CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h)),
            let context = CGContext(
                data: nil, width: rect.w, height: rect.h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw LoadError.invalidFrame(frameName) }
        let offset = info.renderOffsetPx
        context.draw(piece, in: CGRect(x: offset.x, y: -offset.y, width: rect.w, height: rect.h))
        guard let image = context.makeImage() else { throw LoadError.invalidFrame(frameName) }
        return image
    }
}

/// The parts of the sprite metadata JSON that Stercorarius uses.
private struct Metadata: Decodable {
    struct Rect: Decodable {
        let x: Int
        let y: Int
        let w: Int
        let h: Int
    }

    struct Offset: Decodable {
        let x: Int
        let y: Int
    }

    struct FrameInfo: Decodable {
        let frame: Rect
        let durationMs: Double
        let renderOffsetPx: Offset
    }

    struct Animation: Decodable {
        let frames: [String]
    }

    struct Meta: Decodable {
        let pixelRatio: Double
    }

    let frames: [String: FrameInfo]
    let animations: [String: Animation]
    let meta: Meta
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test -Xswiftc -warnings-as-errors --filter SpriteSheetTests 2>&1 | tail -5`
Expected: 6 tests pass.

- [ ] **Step 5: Lint and commit**

```bash
swiftlint lint --strict --quiet && swift format lint --strict --recursive Sources Tests
git add Sources/Stercorarius/SpriteSheet.swift Tests/StercorariusTests/SpriteSheetTests.swift
git commit -m "Add sprite sheet loader for the beetle atlases"
```

---

### Task 5: Pass planner

**Files:**
- Create: `Sources/Stercorarius/PassPlanner.swift`
- Test: `Tests/StercorariusTests/PassPlannerTests.swift`

**Interfaces:**
- Produces: `struct Pass: Equatable { let start: CGPoint; let end: CGPoint; let duration: CFTimeInterval; let isLeftward: Bool }`, `enum PassPlanner { static let speed: CGFloat = 100; static func plan(sprite: CGSize, screenFrame: CGRect, visibleFrame: CGRect, leftward: Bool, heightFraction: CGFloat) -> Pass }`

- [ ] **Step 1: Write the failing tests**

```swift
import CoreGraphics
import Testing

@testable import Stercorarius

@Suite struct PassPlannerTests {
    private let sprite = CGSize(width: 200, height: 100)
    // A 1000×800 display right of the main one, with a 30 pt menu bar and a 70 pt Dock.
    private let screen = CGRect(x: 1440, y: 0, width: 1000, height: 800)
    private let visible = CGRect(x: 1440, y: 70, width: 1000, height: 700)

    private func plan(leftward: Bool, height: CGFloat, sprite: CGSize? = nil) -> Pass {
        PassPlanner.plan(
            sprite: sprite ?? self.sprite, screenFrame: screen, visibleFrame: visible,
            leftward: leftward, heightFraction: height)
    }

    @Test func rightwardPassCrossesFromOffLeftToOffRight() {
        let pass = plan(leftward: false, height: 0)
        #expect(pass.start == CGPoint(x: -100, y: 120))
        #expect(pass.end == CGPoint(x: 1100, y: 120))
        #expect(pass.duration == 12)
        #expect(!pass.isLeftward)
    }

    @Test func leftwardPassRunsBackAtTheTopOfTheVisibleBand() {
        let pass = plan(leftward: true, height: 1)
        #expect(pass.start == CGPoint(x: 1100, y: 720))
        #expect(pass.end == CGPoint(x: -100, y: 720))
        #expect(pass.isLeftward)
    }

    @Test func heightFractionIsClampedToTheVisibleBand() {
        #expect(plan(leftward: false, height: -0.5).start.y == 120)
        #expect(plan(leftward: false, height: 7).start.y == 720)
        #expect(plan(leftward: false, height: 0.5).start.y == 420)
    }

    @Test func spriteTallerThanTheVisibleBandSitsAtItsBottom() {
        let tall = CGSize(width: 200, height: 900)
        #expect(plan(leftward: false, height: 0.5, sprite: tall).start.y == 520)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PassPlannerTests 2>&1 | tail -5`
Expected: compile error `cannot find 'PassPlanner' in scope`.

- [ ] **Step 3: Implement `PassPlanner.swift`**

```swift
import CoreGraphics

/// One walk across a display, in the coordinates of that display's overlay window.
struct Pass: Equatable {
    let start: CGPoint
    let end: CGPoint
    let duration: CFTimeInterval
    let isLeftward: Bool
}

enum PassPlanner {
    /// Walking speed in points per second.
    static let speed: CGFloat = 100

    /// Plans a walk that starts fully past one edge of the display and ends fully past the other,
    /// at a height inside `visibleFrame` chosen by `heightFraction` (0 lowest, 1 highest).
    /// `screenFrame` and `visibleFrame` are global (`NSScreen.frame`, `NSScreen.visibleFrame`);
    /// the result is relative to `screenFrame`'s origin.
    static func plan(
        sprite: CGSize, screenFrame: CGRect, visibleFrame: CGRect, leftward: Bool,
        heightFraction: CGFloat
    ) -> Pass {
        let lowest = visibleFrame.minY - screenFrame.minY + sprite.height / 2
        let highest = max(lowest, visibleFrame.maxY - screenFrame.minY - sprite.height / 2)
        let y = lowest + (highest - lowest) * min(max(heightFraction, 0), 1)
        let left = CGPoint(x: -sprite.width / 2, y: y)
        let right = CGPoint(x: screenFrame.width + sprite.width / 2, y: y)
        return Pass(
            start: leftward ? right : left,
            end: leftward ? left : right,
            duration: (screenFrame.width + sprite.width) / speed,
            isLeftward: leftward)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test -Xswiftc -warnings-as-errors --filter PassPlannerTests 2>&1 | tail -5`
Expected: 4 tests pass.

- [ ] **Step 5: Lint and commit**

```bash
swiftlint lint --strict --quiet && swift format lint --strict --recursive Sources Tests
git add Sources/Stercorarius/PassPlanner.swift Tests/StercorariusTests/PassPlannerTests.swift
git commit -m "Add pass planner for walks across a display"
```

---

### Task 6: Overlay stage, walkers and app shell

**Files:**
- Create: `Sources/Stercorarius/Stage.swift`, `Sources/Stercorarius/Walker.swift`, `Sources/Stercorarius/AppDelegate.swift`
- Modify: `Sources/Stercorarius/main.swift` (whole file below)

**Interfaces:**
- Consumes: `SessionScanner`, `SpriteSheet.bundled(for:)`, `SpriteSheet.keyTimes`, `SpriteSheet.cycleDuration`, `PassPlanner.plan(...)`, `Agent`, `Session`.
- Produces: `@MainActor final class Overlay { init(screen:); func host(_: CALayer); func hideIfEmpty(); func hide() }`, `@MainActor final class Stage { init(sprites: [Agent: SpriteSheet]); func show(_ busy: Set<Session>); func randomScreen() -> (screen: NSScreen, overlay: Overlay)? }`, `@MainActor final class Walker { init(sprite:stage:); func start(); func restartPass(); func retire() }`, `@MainActor final class AppDelegate: NSObject, NSApplicationDelegate`.

This task is UI glue verified by running the app (Step 4); its logic lives in the unit-tested types above.

- [ ] **Step 1: Implement `Stage.swift`**

```swift
import AppKit

/// A transparent, click-through window covering one display, above all other windows on every
/// Space, full-screen apps included. Hosts walker layers and hides itself while empty.
@MainActor
final class Overlay {
    private let window: NSWindow

    init(screen: NSScreen) {
        window = NSWindow(
            contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
        ]
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        window.contentView = view
        window.setFrame(screen.frame, display: false)
    }

    /// Moves `layer` into this window and shows the window.
    func host(_ layer: CALayer) {
        window.contentView?.layer?.addSublayer(layer)
        window.orderFrontRegardless()
    }

    /// Hides the window once no walker layer is left in it.
    func hideIfEmpty() {
        if window.contentView?.layer?.sublayers?.isEmpty ?? true { hide() }
    }

    func hide() { window.orderOut(nil) }
}

/// Owns one overlay per display and one walker per working session.
@MainActor
final class Stage {
    private let sprites: [Agent: SpriteSheet]
    private var overlays: [CGDirectDisplayID: Overlay] = [:]
    private var walkers: [Session: Walker] = [:]

    init(sprites: [Agent: SpriteSheet]) {
        self.sprites = sprites
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    /// Starts walkers for sessions that began working and retires those whose session stopped.
    func show(_ busy: Set<Session>) {
        for session in busy where walkers[session] == nil {
            guard let sprite = sprites[session.agent] else { continue }
            let walker = Walker(sprite: sprite, stage: self)
            walkers[session] = walker
            walker.start()
        }
        for (session, walker) in walkers where !busy.contains(session) {
            walkers[session] = nil
            walker.retire()
        }
    }

    /// A random display and its overlay, or nil when no display is attached.
    func randomScreen() -> (screen: NSScreen, overlay: Overlay)? {
        guard let screen = NSScreen.screens.randomElement() else { return nil }
        if let overlay = overlays[screen.displayID] { return (screen, overlay) }
        let overlay = Overlay(screen: screen)
        overlays[screen.displayID] = overlay
        return (screen, overlay)
    }

    /// Displays were added, removed or rearranged: rebuild overlays and restart every pass.
    private func screensChanged() {
        overlays.values.forEach { $0.hide() }
        overlays = [:]
        walkers.values.forEach { $0.restartPass() }
    }
}

extension NSScreen {
    fileprivate var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }
}
```

- [ ] **Step 2: Implement `Walker.swift`**

```swift
import AppKit
import QuartzCore

/// One beetle: a layer that crosses random displays, alternating direction, until retired.
@MainActor
final class Walker {
    private let sprite: SpriteSheet
    private unowned let stage: Stage
    private let layer = CALayer()
    private var overlay: Overlay?
    private var leftward = false
    private var retired = false

    init(sprite: SpriteSheet, stage: Stage) {
        self.sprite = sprite
        self.stage = stage
        layer.bounds = CGRect(origin: .zero, size: sprite.size)
        layer.contents = sprite.frames.first?.image
    }

    func start() { startPass() }

    /// Abandons the current pass (its display may be gone) and starts a new one.
    func restartPass() {
        layer.removeAnimation(forKey: "move")
        startPass()
    }

    /// Fades the beetle out, then removes it.
    func retire() {
        retired = true
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.3
        // CAAnimation retains its delegate, which keeps this walker alive until the fade ends.
        fade.delegate = AnimationEnd { self.remove() }
        layer.opacity = 0
        layer.add(fade, forKey: "fade")
    }

    private func startPass() {
        guard !retired, let target = stage.randomScreen() else { return }
        let pass = PassPlanner.plan(
            sprite: sprite.size, screenFrame: target.screen.frame,
            visibleFrame: target.screen.visibleFrame, leftward: leftward,
            heightFraction: .random(in: 0...1))
        leftward.toggle()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let previous = overlay
        overlay = target.overlay
        target.overlay.host(layer)
        if previous !== target.overlay { previous?.hideIfEmpty() }
        layer.transform = pass.isLeftward ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
        layer.position = pass.end
        CATransaction.commit()

        layer.add(walkCycle(), forKey: "frames")
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: pass.start)
        move.toValue = NSValue(point: pass.end)
        move.duration = pass.duration
        move.timingFunction = CAMediaTimingFunction(name: .linear)
        move.delegate = AnimationEnd { self.startPass() }
        layer.add(move, forKey: "move")
    }

    /// The frame animation; re-added each pass because the layer may change windows.
    private func walkCycle() -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = sprite.frames.map(\.image)
        animation.keyTimes = sprite.keyTimes
        animation.duration = sprite.cycleDuration
        animation.calculationMode = .discrete
        animation.repeatCount = .infinity
        return animation
    }

    private func remove() {
        layer.removeAllAnimations()
        layer.removeFromSuperlayer()
        overlay?.hideIfEmpty()
        overlay = nil
    }
}

/// Runs `action` when an animation finishes; not when it is removed early.
private final class AnimationEnd: NSObject, CAAnimationDelegate {
    private let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    nonisolated func animationDidStop(_ animation: CAAnimation, finished: Bool) {
        guard finished else { return }
        MainActor.assumeIsolated { action() }
    }
}
```

- [ ] **Step 3: Implement `AppDelegate.swift` and the final `main.swift`**

`Sources/Stercorarius/AppDelegate.swift`:

```swift
import AppKit

/// Polls session records once a second and keeps one beetle per working session on screen.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let scanner = SessionScanner(
        directories: Dictionary(
            uniqueKeysWithValues: Agent.allCases.map { agent in
                (agent, agent.sessionDirectory(home: FileManager.default.homeDirectoryForCurrentUser))
            }))
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var stage: Stage?
    private var statusItem: NSStatusItem?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let sprites: [Agent: SpriteSheet]
        do {
            sprites = try Dictionary(
                uniqueKeysWithValues: Agent.allCases.map { ($0, try SpriteSheet.bundled(for: $0)) })
        } catch {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Stercorarius cannot load its sprites"
            alert.informativeText = String(describing: error)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        stage = Stage(sprites: sprites)
        statusItem = makeStatusItem()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        let busy = scanner.busySessions()
        stage?.show(busy)
        statusLine.title = Agent.allCases
            .map { agent in "\(agent.displayName) \(busy.count { $0.agent == agent })" }
            .joined(separator: " · ")
    }

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "ladybug.fill", accessibilityDescription: "Stercorarius")
        let menu = NSMenu()
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit Stercorarius", action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"))
        item.menu = menu
        return item
    }
}
```

`Sources/Stercorarius/main.swift`:

```swift
import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "codex-hook" {
    exit(CodexHook.execute(arguments: Array(arguments.dropFirst())))
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
```

- [ ] **Step 4: Build, run and look**

```bash
swift build -Xswiftc -warnings-as-errors 2>&1 | tail -5
.build/debug/Stercorarius &
sleep 4
screencapture -x "$TMPDIR/stercorarius-check.png"
```

Expected: the build is clean. The Claude Code session running these commands is `busy`, so a copper beetle rolls across a display and appears in the screenshot (view the PNG). The menu-bar ladybug menu shows `Claude N · Codex M` with N ≥ 1. Quit with the menu's `Quit Stercorarius`.

- [ ] **Step 5: Full test run, lint and commit**

```bash
swift test -Xswiftc -warnings-as-errors 2>&1 | tail -5
swiftlint lint --strict --quiet && swift format lint --strict --recursive Sources Tests
git add Sources/Stercorarius/Stage.swift Sources/Stercorarius/Walker.swift Sources/Stercorarius/AppDelegate.swift Sources/Stercorarius/main.swift
git commit -m "Add overlay stage, walking beetles and menu-bar app shell"
```

---

### Task 7: App bundle, Codex hook installer, Makefile, README

**Files:**
- Create: `Support/Info.plist`, `Scripts/build-app.sh`, `Scripts/codex-hooks.sh`, `Scripts/test-codex-hooks.sh`, `Makefile`, `README.md`

**Interfaces:**
- Consumes: the `Stercorarius` executable and its `Stercorarius_Stercorarius.bundle` from `swift build -c release`.
- Produces: `make build|test|lint|app|install|uninstall`; `Scripts/codex-hooks.sh install|uninstall <binary>`.

- [ ] **Step 1: Write the failing installer test**

`Scripts/test-codex-hooks.sh`:

```bash
#!/bin/bash
# Tests Scripts/codex-hooks.sh against fixture hooks.json files in a temporary CODEX_HOME.
set -euo pipefail

cd "$(dirname "$0")/.."

readonly SCRIPT="$PWD/Scripts/codex-hooks.sh"
readonly JQ=/usr/bin/jq
readonly BIN=/Apps/Stercorarius.app/Contents/MacOS/Stercorarius
WORK="$(mktemp -d)"
readonly WORK
trap 'rm -r "$WORK"' EXIT
export CODEX_HOME="$WORK"
readonly HOOKS="$WORK/hooks.json"
failures=0

check() {
  local description="$1"
  shift
  if "$@"; then
    echo "ok   - $description"
  else
    echo "FAIL - $description"
    failures=$((failures + 1))
  fi
}

fails_quietly() { ! "$@" 2>/dev/null; }

value() { "$JQ" -r "$1" "$HOOKS"; }

cat >"$HOOKS" <<'JSON'
{
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "/x/notify.sh" }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "/x/notify.sh" }] }],
    "PreCompact": []
  }
}
JSON
cp "$HOOKS" "$WORK/original.json"

"$SCRIPT" install "$BIN" >/dev/null
check "install keeps the existing Stop group first" \
  test "$(value '.hooks.Stop[0].hooks[0].command')" = /x/notify.sh
check "install appends the idle hook to Stop" \
  test "$(value '.hooks.Stop[1].hooks[0].command')" = "$BIN codex-hook idle"
check "install adds the busy hook to UserPromptSubmit" \
  test "$(value '.hooks.UserPromptSubmit[0].hooks[0].command')" = "$BIN codex-hook busy"
check "install adds the idle hook to Interrupt" \
  test "$(value '.hooks.Interrupt[0].hooks[0].command')" = "$BIN codex-hook idle"
check "install adds the idle hook to SessionEnd" \
  test "$(value '.hooks.SessionEnd[0].hooks[0].command')" = "$BIN codex-hook idle"
check "install leaves SessionStart alone" \
  test "$(value '.hooks.SessionStart | tojson')" = \
  "$("$JQ" -r '.hooks.SessionStart | tojson' "$WORK/original.json")"
check "install adds no top-level keys" test "$(value 'keys | tojson')" = '["hooks"]'
check "install backs up the original" \
  test "$(find "$WORK" -name 'hooks.json.stercorarius-*.bak' | wc -l | tr -d ' ')" = 1

cp "$HOOKS" "$WORK/installed.json"
"$SCRIPT" install "$BIN" >/dev/null
check "a second install leaves the file byte-identical" cmp -s "$HOOKS" "$WORK/installed.json"

"$SCRIPT" install /Other/Stercorarius >/dev/null
check "installing from a new path leaves four Stercorarius commands" \
  test "$(value '[.. | .command? // empty | select(contains("Stercorarius codex-hook"))] | length')" = 4
check "installing from a new path keeps the existing Stop group first" \
  test "$(value '.hooks.Stop[0].hooks[0].command')" = /x/notify.sh

"$SCRIPT" uninstall /Other/Stercorarius >/dev/null
check "uninstall restores the original content" \
  test "$("$JQ" -S . "$HOOKS")" = "$("$JQ" -S . "$WORK/original.json")"

rm "$HOOKS"
"$SCRIPT" install "$BIN" >/dev/null
check "install creates a missing hooks.json" \
  test "$(value '.hooks.UserPromptSubmit[0].hooks[0].command')" = "$BIN codex-hook busy"

echo '{"hooks": []}' >"$HOOKS"
cp "$HOOKS" "$WORK/invalid.json"
check "install rejects a hooks.json whose .hooks is not an object" \
  fails_quietly "$SCRIPT" install "$BIN"
check "a rejected hooks.json is left untouched" cmp -s "$HOOKS" "$WORK/invalid.json"

if [ "$failures" -gt 0 ]; then
  echo "$failures installer check(s) failed"
  exit 1
fi
echo "All installer checks passed"
```

Run: `chmod +x Scripts/test-codex-hooks.sh && Scripts/test-codex-hooks.sh`
Expected: FAIL — `Scripts/codex-hooks.sh: No such file or directory`.

- [ ] **Step 2: Implement `Scripts/codex-hooks.sh`**

```bash
#!/bin/bash
# Adds or removes Stercorarius's hooks in Codex's hooks.json ($CODEX_HOME, default ~/.codex).
# Usage: Scripts/codex-hooks.sh install|uninstall <path to the Stercorarius binary>
#
# Codex rejects the whole file when it has an unknown top-level key, and its hook trust keys
# depend on array positions. So this only appends groups to .hooks.<Event> arrays and removes
# its own handlers; everything else stays as it was.
set -euo pipefail

readonly USAGE="usage: $0 install|uninstall <stercorarius-binary>"
readonly ACTION="${1:?$USAGE}"
readonly BINARY="${2:?$USAGE}"
readonly JQ=/usr/bin/jq
readonly HOOKS_FILE="${CODEX_HOME:-$HOME/.codex}/hooks.json"
TMP_FILE=""
trap 'if [ -n "$TMP_FILE" ]; then rm -f "$TMP_FILE"; fi' EXIT

# jq definitions shared by every invocation; $bin is the Stercorarius binary.
readonly DEFS='
def ours: (.command // "") | contains("Stercorarius codex-hook");
def wanted: {
  UserPromptSubmit: "\($bin) codex-hook busy",
  Stop: "\($bin) codex-hook idle",
  Interrupt: "\($bin) codex-hook idle",
  SessionEnd: "\($bin) codex-hook idle"
};
def checked:
  if ((.hooks // {}) | type) == "object" then . else error("hooks.json: .hooks must be an object") end;
def installed: . as $root
  | all(wanted | to_entries[]; . as $e | any($root.hooks[$e.key][]?.hooks[]?; .command == $e.value));
def has_ours: any(.hooks[]?[]?.hooks[]?; ours);
def strip_group: if any(.hooks[]?; ours) then .hooks |= map(select(ours | not)) else . end;
def strip:
  .hooks |= (to_entries
    | map((.value | any(.[]?.hooks[]?; ours)) as $had
      | .value |= (if $had then map(strip_group | select(.hooks | length > 0)) else . end)
      | select(($had and .value == []) | not))
    | from_entries);
def append_ours:
  reduce (wanted | to_entries[]) as $e (.;
    .hooks[$e.key] = ((.hooks[$e.key] // []) + [{hooks: [{type: "command", command: $e.value}]}]));
'

run_jq() { "$JQ" --arg bin "$BINARY" "$DEFS $1" "${@:2}"; }

# Rewrites hooks.json through the jq filter $1: backup, validate, then atomic replace.
rewrite() {
  TMP_FILE="$(mktemp "$HOOKS_FILE.XXXXXX")"
  run_jq "$1" "$HOOKS_FILE" >"$TMP_FILE"
  "$JQ" empty "$TMP_FILE"
  chmod "$(stat -f %Lp "$HOOKS_FILE")" "$TMP_FILE"
  cp -p "$HOOKS_FILE" "$HOOKS_FILE.stercorarius-$(date +%Y%m%d-%H%M%S)-$$.bak"
  mv "$TMP_FILE" "$HOOKS_FILE"
  TMP_FILE=""
}

install_hooks() {
  if [ ! -f "$HOOKS_FILE" ]; then
    mkdir -p "$(dirname "$HOOKS_FILE")"
    run_jq '{hooks: {}} | append_ours' -n >"$HOOKS_FILE"
  elif run_jq 'checked | installed' -e "$HOOKS_FILE" >/dev/null; then
    echo "Stercorarius hooks are already in $HOOKS_FILE."
    return
  else
    rewrite 'checked | .hooks //= {} | strip | append_ours'
  fi
  cat <<EOF
Installed Stercorarius hooks in $HOOKS_FILE.
Next steps:
  1. Trust the hooks once: start \`codex\` and accept "Hooks need review" (or run /hooks),
     or open ChatGPT.app > Settings > Hooks.
  2. Restart Codex sessions and ChatGPT.app; threads that are already loaded keep their old hooks.
EOF
}

uninstall_hooks() {
  if [ -f "$HOOKS_FILE" ] && run_jq 'has_ours' -e "$HOOKS_FILE" >/dev/null; then
    rewrite 'strip'
    echo "Removed Stercorarius hooks from $HOOKS_FILE."
  else
    echo "No Stercorarius hooks in $HOOKS_FILE."
  fi
}

case "$ACTION" in
  install) install_hooks ;;
  uninstall) uninstall_hooks ;;
  *)
    echo "$USAGE" >&2
    exit 2
    ;;
esac
```

Note: `run_jq` passes extra jq options (`-n`, `-e`) after the filter; jq accepts options anywhere on its command line.

- [ ] **Step 3: Run the installer test to verify it passes**

Run: `chmod +x Scripts/codex-hooks.sh && Scripts/test-codex-hooks.sh`
Expected: every line `ok   - …`, then `All installer checks passed`.

- [ ] **Step 4: Add `Support/Info.plist` and `Scripts/build-app.sh`**

`Support/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Stercorarius</string>
    <key>CFBundleIdentifier</key>
    <string>com.jamg.Stercorarius</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Stercorarius</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
```

`Scripts/build-app.sh`:

```bash
#!/bin/bash
# Builds .build/Stercorarius.app from the SwiftPM package and signs it: with a
# "Developer ID Application" identity when one is installed, ad-hoc otherwise.
set -euo pipefail

cd "$(dirname "$0")/.."

readonly APP=".build/Stercorarius.app"
readonly SIGN_IDENTITY="${STERCORARIUS_SIGN_IDENTITY:-Developer ID Application}"

swift build -c release -Xswiftc -warnings-as-errors
BIN_DIR="$(swift build -c release --show-bin-path)"
readonly BIN_DIR

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ditto "$BIN_DIR/Stercorarius" "$APP/Contents/MacOS/Stercorarius"
ditto Support/Info.plist "$APP/Contents/Info.plist"
ditto "$BIN_DIR/Stercorarius_Stercorarius.bundle" \
  "$APP/Contents/Resources/Stercorarius_Stercorarius.bundle"

if security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
echo "Built $APP"
```

Run: `chmod +x Scripts/build-app.sh && Scripts/build-app.sh && codesign --verify --deep --strict .build/Stercorarius.app && echo signed-ok`
Expected: `Built .build/Stercorarius.app`, `signed-ok`.

- [ ] **Step 5: Add the `Makefile`**

```make
APP_NAME := Stercorarius
BUILT_APP := .build/$(APP_NAME).app
INSTALLED_APP := $(HOME)/Applications/$(APP_NAME).app
BINARY := $(INSTALLED_APP)/Contents/MacOS/$(APP_NAME)

.PHONY: build test lint app quit install uninstall

build:
	swift build -Xswiftc -warnings-as-errors

test:
	swift test -Xswiftc -warnings-as-errors
	Scripts/test-codex-hooks.sh

lint:
	swiftlint lint --strict --quiet
	swift format lint --strict --recursive Package.swift Sources Tests
	shellcheck Scripts/*.sh
	shfmt -d -i 2 Scripts

app:
	Scripts/build-app.sh

quit:
	@if pgrep -xq $(APP_NAME); then osascript -e 'quit app "$(APP_NAME)"'; fi

install: app quit
	mkdir -p $(HOME)/Applications
	ditto $(BUILT_APP) $(INSTALLED_APP)
	Scripts/codex-hooks.sh install $(BINARY)
	open $(INSTALLED_APP)

uninstall: quit
	Scripts/codex-hooks.sh uninstall $(BINARY)
	if [ -d $(INSTALLED_APP) ]; then trash $(INSTALLED_APP); fi
	if [ -d $(HOME)/.stercorarius ]; then trash $(HOME)/.stercorarius; fi
```

Run: `make lint test`
Expected: no lint output; all Swift tests and installer checks pass.

- [ ] **Step 6: Write `README.md`**

````markdown
# Stercorarius

A macOS menu-bar app that sends a dung beetle rolling across your screens for every Claude Code or
Codex session that is working right now. (*Geotrupes stercorarius* is the dor beetle.)

## How it works

- **Claude Code** keeps a registry of running sessions in `~/.claude/sessions/<pid>.json`, with a
  `status` of `busy`, `idle` or `waiting`. Stercorarius reads it once a second and never writes to
  `~/.claude`.
- **Codex** runs desktop threads and TUI sessions inside shared app-server processes, so
  Stercorarius registers Codex hooks: `UserPromptSubmit` runs `Stercorarius codex-hook busy`;
  `Stop`, `Interrupt` and `SessionEnd` run `Stercorarius codex-hook idle`. The hook keeps one file
  per working session in `~/.stercorarius/codex/`.
- Each working session gets a beetle. It crosses a random display at a random height, left to
  right, then mirrored right to left, above all windows on every Space, and lets clicks through.
  When the session stops working, its beetle fades out.

## Install

```sh
make install
```

This builds `Stercorarius.app` into `~/Applications`, appends four hooks to `~/.codex/hooks.json`
(after saving a backup next to it), and starts the app. Then, once:

1. Trust the hooks: start `codex` and accept "Hooks need review" (or run `/hooks`), or open
   ChatGPT.app > Settings > Hooks.
2. Restart Codex sessions and ChatGPT.app; threads that are already loaded keep their old hooks.

Stercorarius does not start at login; open it from `~/Applications`. The menu-bar ladybug shows
how many sessions are working and has a Quit item.

## Uninstall

```sh
make uninstall
```

Quits the app, removes its hooks from `~/.codex/hooks.json` (with a backup), and moves the app and
`~/.stercorarius` to the Trash.

## Sprites

`Sources/Stercorarius/Resources/Sprites` holds the sprite pack; its `README.md` and
`preview.html` describe it. Each agent has a PNG atlas plus TexturePacker-style JSON
(`claude-code.*`, `chatgpt-codex.*`): frame rectangles, per-frame `durationMs` and
`renderOffsetPx`, the `animations.move_right` frame order, and `meta.pixelRatio`. Frames show
rightward travel; leftward passes mirror them. To change a beetle, replace its two files and run
`make install`.

## Development

```sh
make build   # debug build, warnings are errors
make test    # Swift tests and installer checks
make lint    # swiftlint, swift format, shellcheck, shfmt
make app     # .build/Stercorarius.app
swift run Stercorarius
```

## Known limitations

- A Codex turn that ends in an API error (rate or usage limit) fires no hook; its beetle keeps
  walking until that thread's next `Stop`, `Interrupt` or `SessionEnd`.
- If another Codex `Stop` hook blocks and the turn continues, the beetle leaves early.
- Claude Code's session registry format is undocumented; an update may need a decoder change.
- Codex threads loaded before installation do not run the new hooks until restarted.
````

- [ ] **Step 7: Commit**

```bash
git add Support Scripts Makefile README.md
git commit -m "Add app bundle script, Codex hook installer, Makefile and README"
```

---

### Task 8: End-to-end verification

**Files:** none new; fixes go to the files of the task they belong to.

- [ ] **Step 1: Full gate**

Run: `make lint test app`
Expected: clean lint, all tests pass, `Built .build/Stercorarius.app`.

- [ ] **Step 2: Claude beetle**

```bash
open .build/Stercorarius.app
sleep 4
screencapture -x "$TMPDIR/stercorarius-claude.png"
```

Expected: this Claude Code session is `busy` while the commands run, so the screenshot (view it) shows a copper beetle with its ball; the menu line reads `Claude N · Codex 0` with N ≥ 1.

- [ ] **Step 3: Codex beetle through real hooks, without touching `~/.codex`**

Session-level hook overrides (`-c hooks.<Event>=…`) plus `--dangerously-bypass-hook-trust` apply to this one run only. `hooks.state` disables the user's two existing hooks (Superset) and `notify=[]` the legacy notifier, so the run has no side effects outside Stercorarius:

```bash
BIN="$PWD/.build/Stercorarius.app/Contents/MacOS/Stercorarius"
USER_HOOKS="$HOME/.codex/hooks.json"
group() { printf '[{hooks=[{type="command",command="%s codex-hook %s"}]}]' "$BIN" "$1"; }
codex exec --skip-git-repo-check --dangerously-bypass-hook-trust \
  -m gpt-6-astra -c 'model_reasoning_effort="low"' -c 'notify=[]' \
  -c "hooks.state={\"$USER_HOOKS:session_start:0:0\"={enabled=false},\"$USER_HOOKS:stop:0:0\"={enabled=false}}" \
  -c "hooks.UserPromptSubmit=$(group busy)" -c "hooks.Stop=$(group idle)" \
  -c "hooks.Interrupt=$(group idle)" -c "hooks.SessionEnd=$(group idle)" \
  "Write about 300 words on how dung beetles steer by the Milky Way." </dev/null >/dev/null &
sleep 8
ls ~/.stercorarius/codex/ && cat ~/.stercorarius/codex/*.json
screencapture -x "$TMPDIR/stercorarius-codex.png"
wait
ls ~/.stercorarius/codex/
```

Expected: one `<session_id>.json` with `{"pid":…,"status":"busy"}` whose PID is the `codex` binary; a dark-green beetle in the screenshot; after the run ends, the file is gone and the beetle fades out.

- [ ] **Step 4: Quit and report**

Quit via the menu (or `osascript -e 'quit app "Stercorarius"'`). Report results with screenshots. `make install` modifies `~/.codex/hooks.json`; run it only as the final step once everything above passes.
