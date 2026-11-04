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
