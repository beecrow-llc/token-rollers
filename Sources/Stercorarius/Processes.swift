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
